# Final projections only: no device queries, printer/account changes or installs.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
$project=Split-Path $PSScriptRoot -Parent
$output=Join-Path $project ('output/final-inventory/'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($output)
function Assert-FinalInventory {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Decode-FinalInventory {param($Snapshot) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Snapshot.HtmlBase64))}
foreach($client in @('SaaS','Subway')){
    $source=$client
    Set-KioskTestClient -ClientType $client
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $project 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
    Assert-FinalInventory (-not $errors.Count) 'Source parse failed'
    . ([scriptblock]::Create(($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object {$_.Extent.Text}) -join "`n"))
    function Get-LocalUser {throw 'Final selection queried real accounts'}
    function Get-CimInstance {throw 'Final selection queried the device'}
    function Get-Printer {throw 'Final selection queried real printers'}
    function Set-LocalUser {throw 'Final selection changed an account'}
    function Set-Printer {throw 'Final selection changed a printer'}
    function Read-Host {throw 'Final selection requested input'}
    function New-FinalPrinter {
        param([string]$Name,[string]$State,[string]$Keep='Enabled',[string]$Action='Printer properties inspected; readback verified.')
        [pscustomobject]@{SectionNumber=1;SectionTitle='Hardware & Peripherals';ItemTitle=$Name;ItemSub='Type: Receipt / POS Printer';Shortcut=(New-ReportCommand @('control printers'));FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Printer Name'=$Name;'Printer status'=$State;'Keep printed documents'=$Keep}));Status=$(if($State -in @('Active','Idle') -and $Keep -eq 'Enabled'){'Pass'}else{'Fail'});ActionTaken=$Action}
    }
    function New-FinalAdmin {
        param([string]$Name,[string]$State='Active',[string]$Privilege='Local Administrator',[string]$Password='Enabled',[string]$Action='Password Never Expires readback verified.')
        [pscustomobject]@{AccountName=$Name;Status=$(if($Password -eq 'Enabled'){'Pass'}else{'Fail'});Action=$Action;StateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'=$Name;'Account Privilege'=$Privilege;'Account Status'=$State;'Password Never Expires'=$Password}))}
    }
    function New-FinalAdminRow {
        param([object[]]$Entries)
        [pscustomobject]@{SectionNumber=4;SectionTitle='Security, Network & System Integrity';ItemTitle='Administrative Accounts';ItemSub='Verified configuration';Shortcut=(New-ReportCommand @('lusrmgr.msc'));FoundStateHtml=(($Entries|ForEach-Object {$_.StateHtml}) -join '<hr>');Status='Fail';ActionTaken='Multiple administrative account observations';AccountResults=$Entries}
    }
    $printers=@(
        (New-FinalPrinter 'EPSON Unavailable' 'Not available'),
        (New-FinalPrinter 'EPSON Offline' Offline),
        (New-FinalPrinter 'EPSON Idle & <Front>' Idle Disabled),
        (New-FinalPrinter 'BIXOLON Active' Active),
        (New-FinalPrinter 'EPSON Paused' Paused),
        (New-FinalPrinter 'EPSON Error' Error),
        (New-FinalPrinter 'EPSON Unknown' 'Not verified')
    )
    $log=[pscustomobject]@{SectionNumber=1;SectionTitle='Hardware & Peripherals';ItemTitle='PrintService Operational Log';ItemSub='';Shortcut='';FoundStateHtml=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Log State'='Enabled'}));Status='Pass';ActionTaken='Log state verified'}
    $admins=New-FinalAdminRow @((New-FinalAdmin Administrator),(New-FinalAdmin 'Other Admin'),(New-FinalAdmin Admin))
    $rows=$printers+@($log,$admins)
    $identity=[pscustomobject]@{ReportId='OMK-711235';GeneratedAt='07 Nov 2026, 11:16 AM BST';AgentName='Fixture'}
    $before=$rows|ConvertTo-Json -Depth 14 -Compress
    $audit=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Audit -AuditSource $identity
    $fix=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Fix -AuditSource $identity
    foreach($afterApply in @($false,$true)){
        $final=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Final -AfterApply $afterApply -AuditSource $identity
        $html=Decode-FinalInventory $final
        $view=Get-SettingRenderedComponent $html Printer
        $names=@($view.Fields|Where-Object Setting -EQ 'Printer Name'|ForEach-Object Value)
        $states=@($view.Fields|Where-Object Setting -EQ 'Printer status'|ForEach-Object Value)
        Assert-FinalInventory (($names -join '|') -ceq 'EPSON Idle & <Front>|BIXOLON Active' -and ($states -join '|') -ceq 'Idle|Active') ('Final printer inventory is not restricted to actual Active/Idle records; AfterApply='+$afterApply+'; names='+($names -join '|')+'; states='+($states -join '|'))
        Assert-FinalInventory (@($view.Fields|Where-Object {$_.Setting -eq 'Keep printed documents' -and $_.Value -eq 'Disabled'}).Count -eq 1) 'Eligible printer with a retention issue was hidden or repaired in the report'
        Assert-FinalInventory ((Get-SettingRenderedComponent $html 'PrintService Log').Count -eq 1) 'Printer selection removed PrintService Log'
        $adminView=Get-SettingRenderedComponent $html 'Administrative Accounts'
        Assert-FinalInventory (@($adminView.Fields|Where-Object Setting -EQ 'Account Name').Count -eq 1 -and @($adminView.Fields|Where-Object Setting -EQ 'Account Name')[0].Value -ceq 'Admin') 'Admin did not win priority or multiple admins remained'
        [IO.File]::WriteAllText((Join-Path $output ($client+'-Final-'+$afterApply+'.html')),$html,[Text.UTF8Encoding]::new($false))
    }
    $grouped=@(Get-ThoroughReportDisplayRows $rows)
    $final=New-ThoroughReportSnapshot -Rows $grouped -DisplayMode Final -AfterApply $true -AuditSource $identity
    $view=Get-SettingRenderedComponent (Decode-FinalInventory $final) Printer
    Assert-FinalInventory (@($view.Fields|Where-Object Setting -EQ 'Printer Name').Count -eq 2) 'Saved/grouped printer observations bypassed Final filtering'
    $bad=$printers[3]|Select-Object *;$bad.ActionTaken='Printer readback failed; status not verified.'
    $final=New-ThoroughReportSnapshot -Rows @($printers[2],$bad) -DisplayMode Final -AfterApply $true
    $view=Get-SettingRenderedComponent (Decode-FinalInventory $final) Printer
    Assert-FinalInventory (@($view.Fields|Where-Object Setting -EQ 'Printer Name').Count -eq 1 -and @($view.Fields|Where-Object Setting -EQ 'Printer status')[0].Value -eq 'Idle') 'Unverified post-fix printer status was retained or contaminated its healthy sibling'
    $final=New-ThoroughReportSnapshot -Rows @($printers[0],$printers[1],$log) -DisplayMode Final
    $html=Decode-FinalInventory $final
    Assert-FinalInventory ((Get-SettingRenderedComponent $html Printer).Count -eq 0 -and (Get-SettingRenderedComponent $html 'PrintService Log').Count -eq 1) 'No eligible printers left a false printer row or removed other hardware checks'
    $healthyFix=New-ThoroughReportSnapshot -Rows @($printers[3]) -DisplayMode Fix
    Assert-FinalInventory ((Decode-FinalInventory $healthyFix).Contains('No fixes required.')) 'Single-row Fix lost its array shape or no-fixes message'
    $adminCases=@(
        @{Entries=@((New-FinalAdmin Admin Disabled),(New-FinalAdmin Administrator),(New-FinalAdmin Other));Expected='Administrator'},
        @{Entries=@((New-FinalAdmin Admin Active 'Standard Local User'),(New-FinalAdmin Administrator),(New-FinalAdmin Other));Expected='Administrator'},
        @{Entries=@((New-FinalAdmin Admin Disabled),(New-FinalAdmin Administrator Disabled),(New-FinalAdmin Zeta),(New-FinalAdmin Beta));Expected='Beta'},
        @{Entries=@((New-FinalAdmin Admin Active 'Local Administrator' Disabled 'Password remains disabled; readback verified.'),(New-FinalAdmin Administrator));Expected='Admin'},
        @{Entries=@((New-FinalAdmin Admin Disabled),(New-FinalAdmin Administrator Active 'Standard Local User'),(New-FinalAdmin Other 'Not verified'));Expected='Administrative account not verified'},
        @{Entries=@((New-FinalAdmin 'Ops & <East>'));Expected='Ops & <East>'},
        @{Entries=@((New-FinalAdmin ADMIN),(New-FinalAdmin Administrator));Expected='ADMIN'},
        @{Entries=@((New-FinalAdmin Admin),(New-FinalAdmin Admin),(New-FinalAdmin Administrator));Expected='Administrator'}
    )
    foreach($case in $adminCases){
        foreach($afterApply in @($false,$true)){
            $row=New-FinalAdminRow $case.Entries
            $final=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Final -AfterApply $afterApply
            $view=Get-SettingRenderedComponent (Decode-FinalInventory $final) 'Administrative Accounts'
            $names=@($view.Fields|Where-Object Setting -EQ 'Account Name')
            Assert-FinalInventory ($names.Count -eq 1 -and $names[0].Value -ceq $case.Expected -and $view.Headings.Count -eq 0) ('Administrative eligibility/priority failed: '+$case.Expected)
        }
    }
    $unverified=New-FinalAdminRow @((New-FinalAdmin Admin Active 'Local Administrator' Enabled 'Account update readback failed.'),(New-FinalAdmin Administrator))
    $final=New-ThoroughReportSnapshot -Rows @($unverified) -DisplayMode Final -AfterApply $true
    $view=Get-SettingRenderedComponent (Decode-FinalInventory $final) 'Administrative Accounts'
    Assert-FinalInventory (@($view.Fields|Where-Object Setting -EQ 'Account Name')[0].Value -eq 'Administrator') 'Unverified higher-priority admin displaced verified evidence'
    $unverified.AccountResults=@()
    $final=New-ThoroughReportSnapshot -Rows @($unverified) -DisplayMode Final -AfterApply $true
    Assert-FinalInventory ((Decode-FinalInventory $final).Contains('Administrative account not verified')) 'Missing admin readback was guessed'
    Assert-FinalInventory (($rows|ConvertTo-Json -Depth 14 -Compress) -ceq $before) 'Final filtering mutated observations'
    $auditAfter=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Audit -AuditSource $identity
    $fixAfter=New-ThoroughReportSnapshot -Rows $rows -DisplayMode Fix -AuditSource $identity
    Assert-FinalInventory ($auditAfter.HtmlBase64 -ceq $audit.HtmlBase64 -and $fixAfter.HtmlBase64 -ceq $fix.HtmlBase64) 'Final inventory rules changed Audit/Fix output'
    $bundle=Join-Path $output ($client+'-bundle.html')
    [void](Save-ThoroughReportBundle -Path $bundle -ClientType $client -ComputerName FIXTURE -Snapshots @($audit) -PreferredMode Audit)
    [void](Save-ThoroughReportBundle -Path $bundle -ClientType $client -ComputerName FIXTURE -Snapshots @($fix,$final) -PreferredMode Final)
    $saved=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($bundle))
    Assert-FinalInventory ($saved.Reports.Audit.HtmlBase64 -ceq $audit.HtmlBase64) 'Saving filtered Final replaced original Audit'
    Write-Output ('PASS: '+$client+' Final Active/Idle printers, independent readback, Admin/Administrator/other active admin priority, unknown/duplicate evidence, unchanged Audit/Fix and saved history.')
}
