
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
# Load definitions and render disposable observations only. Never run device checks.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent;$sourceRoot=$projectRoot
$outputRoot=Join-Path $projectRoot 'output/fix-final-setting-layout'
[void][IO.Directory]::CreateDirectory($outputRoot)
$utf8=New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
$baseline=[KioskTestSource]::ReadAllText((Join-Path $PSScriptRoot 'Fixtures/SettingLayoutLegacyRenderer.json'))|ConvertFrom-Json
function Assert-Setting {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Decode-Setting {param($Snapshot) $utf8.GetString([Convert]::FromBase64String($Snapshot.HtmlBase64))}
function New-SettingFixture {
    param([int]$Section,[string]$Name,$Fields,[string]$Status='Fail',[string]$Action='Audit only',[string]$Sub='',[string]$SectionTitle='Fixture section')
    [pscustomobject]@{SectionNumber=$Section;SectionTitle=$SectionTitle;ItemTitle=$Name;ItemSub=$Sub;Shortcut=(New-ReportCommand @('services.msc'));FoundStateHtml=$(if($Fields -is [Collections.IDictionary]){ConvertTo-ReportDefinitionHtml $Fields}else{[string]$Fields});Status=$Status;ActionTaken=$Action}
}
function New-SettingAccount {
    param([string]$Name,[string]$Flag='Disabled',[string]$Status='Fail',[string]$Action='Audit only',[bool]$Changed=$false)
    [pscustomobject]@{AccountName=$Name;Status=$Status;Action=$Action;AccountPolicyChanged=$Changed;State=(ConvertTo-ReportDefinitionHtml ([ordered]@{'Account Name'=$Name;'Account Privilege'='Standard';'Account Status'='Active';'Password Never Expires'='Enabled';'User Cannot Change Password'=$Flag}))}
}
function New-SettingAccountRow {
    param([object[]]$Accounts)
    $row=New-SettingFixture 2 'KIOSK Account' ('<div class="account-stack">'+(($Accounts|ForEach-Object {$_.State}) -join '<hr>')+'</div>')
    $row.Shortcut=New-AccountReportCommand @($Accounts.AccountName)
    $row.Status=if(@($Accounts|Where-Object Status -NE 'Pass').Count){'Fail'}else{'Pass'}
    $row.ActionTaken=($Accounts.Action -join '; ')
    $row|Add-Member NoteProperty AccountResults @($Accounts)
    $row
}
function Get-SettingField {
    param($Component,[string]$Label,[string]$Record='*')
    $fields=@($Component.Fields|Where-Object {$_.Setting -ceq $Label -and $_.Record -like $Record})
    Assert-Setting ($fields.Count -eq 1) ('Expected one '+$Label+' field in '+$Record+'; found '+$fields.Count)
    $fields[0]
}
function Get-LegacyFieldPairs {
    param([string]$Html)
    @([regex]::Matches($Html,'(?is)<span class="kv-label">(?<Label>[^<]+):</span>\s*(?<Value>.*?)</div>')|ForEach-Object {
        ([Net.WebUtility]::HtmlDecode($_.Groups['Label'].Value).Trim())+'='+([Net.WebUtility]::HtmlDecode(([regex]::Replace($_.Groups['Value'].Value,'<[^>]*>',''))).Trim())
    })
}
foreach($name in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null;$ast=[KioskTestSource]::ParseFile((Join-Path $sourceRoot $name),[ref]$tokens,[ref]$errors)
    Assert-Setting ($errors.Count -eq 0) 'Client source failed parsing.'
    $definitions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
    . ([scriptblock]::Create(($definitions|ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    $old=@($baseline|Where-Object FileName -EQ $name)[0]
    $legacy=& { . ([scriptblock]::Create($old.Renderer)); (Get-Command New-ThoroughReportSnapshot).ScriptBlock }
    # Invoke the captured presentation independently to compare retained
    # components, fields and commands against the new table projection.
    function Get-CimInstance {throw 'Renderer queried the device'}
    function Get-LocalUser {throw 'Renderer queried an account'}
    function Set-LocalUser {throw 'Renderer changed an account'}
    function Set-Service {throw 'Renderer changed a service'}
    function Start-Process {throw 'Renderer started a process'}
    $script:ApplyChanges=$false
    $client=if($name -like 'Subway*'){'Subway'}else{'SaaS'}
    $identity=[pscustomobject]@{ReportId='OMK-241234';GeneratedAt='04 Nov 2026, 1:20 PM BST';AgentName='Fixture Agent'}
    $accountBefore=New-SettingAccountRow @((New-SettingAccount 'Desk & <East>'),(New-SettingAccount 'SELISE-KIOSK'),(New-SettingAccount 'Healthy' Enabled Pass))
    $accountAfter=New-SettingAccountRow @((New-SettingAccount 'SELISE-KIOSK' Disabled Fail 'Required password property remains disabled; readback verified'),(New-SettingAccount 'Healthy' Enabled Pass 'Requested password settings are enabled; no changes needed'),(New-SettingAccount 'Desk & <East>' Enabled Pass 'Enabled User Cannot Change Password; readback verified' $true))
    $beforePrinters=@(
        (New-SettingFixture 1 'EPSON & <Front>' ([ordered]@{'Printer Name'='EPSON & <Front>';'Printer status'='Idle';'Keep printed documents'='Disabled'}) Fail 'Audit only' 'Type: Receipt / POS Printer'),
        (New-SettingFixture 1 'BIXOLON Kitchen' ([ordered]@{'Printer Name'='BIXOLON Kitchen';'Printer status'='Idle';'Keep printed documents'='Enabled'}) Pass 'Audit only' 'Type: Receipt / POS Printer')
    )
    $afterPrinters=@(
        (New-SettingFixture 1 'BIXOLON Kitchen' ([ordered]@{'Printer Name'='BIXOLON Kitchen';'Printer status'='Idle';'Keep printed documents'='Enabled'}) Pass 'No changes needed' 'Type: Receipt / POS Printer'),
        (New-SettingFixture 1 'EPSON & <Front>' ([ordered]@{'Printer Name'='EPSON & <Front>';'Printer status'='Idle';'Keep printed documents'='Enabled'}) Pass 'Enabled Keep printed documents; readback verified' 'Type: Receipt / POS Printer')
    )
    $logBefore=New-SettingFixture 1 'PrintService Operational Log' 'Disabled'
    $logAfter=New-SettingFixture 1 'PrintService Operational Log' 'Enabled' Pass 'PrintService log enabled; readback verified'
    $serviceBefore=New-SettingFixture 3 'Windows Update (wuauserv)' ([ordered]@{'Service State'='Running';'Startup type'='Automatic'}) Fail
    $serviceAfter=New-SettingFixture 3 'Windows Update (wuauserv)' ([ordered]@{'Service State'='Stopped';'Startup type'='Disabled'}) Pass 'Service stopped; Startup set to Disabled; readback verified'
    $counterBefore=New-SettingFixture 4 'lodctr /R Performance Counter' ([ordered]@{'Audit'='Not executed'}) Bypass
    $counterAfter=New-SettingFixture 4 'lodctr /R Performance Counter' ([ordered]@{'Rebuild State'='Exit code: 0'}) Pass 'Performance counters rebuilt; lodctr returned exit code 0'
    $app=New-SettingFixture 5 'Payment Configuration' ([ordered]@{'Value'='Not configured';'PosId'=0;'IsEnabled'=$false}) Pass 'Collected; read only' '' 'AppSettings Check'
    $opaque=New-SettingFixture 4 'Opaque evidence' '<div>Read failed &amp; access denied<br>Retry manually.</div>'
    $before=@($beforePrinters)+@($accountBefore,$logBefore,$serviceBefore,$counterBefore,$app,$opaque)
    $after=@($afterPrinters)+@($accountAfter,$logAfter,$serviceAfter,$counterAfter,$app,$opaque)
    $cases=@(
        @{Name='Pending';Rows=$before;BeforeRows=@();AfterApply=$false},
        @{Name='Applied';Rows=$after;BeforeRows=$before;AfterApply=$true},
        @{Name='NoBaseline';Rows=$after;BeforeRows=@();AfterApply=$true}
    )
    foreach($case in $cases){
        $original=ConvertTo-Json -InputObject @($case.Rows,$case.BeforeRows) -Depth 24 -Compress
        $snapshots=[ordered]@{}
        foreach($mode in @('Audit','Fix','Final')){
            $parameters=@{Rows=$case.Rows;BeforeRows=$case.BeforeRows;DisplayMode=$mode;AfterApply=$case.AfterApply;AuditSource=$identity;DeviceType='KIOSK';Hostname='FIXTURE-PC';LauncherKioskId='Kiosk-1';LauncherRestaurantId='R & <123>';AgentName='Fixture Agent';ClientLocation='Sample branch'}
            $parameters.KioskUserName='Desk & <East>'
            $snapshot=New-ThoroughReportSnapshot @parameters;$snapshots[$mode]=$snapshot;$html=Decode-Setting $snapshot
            [IO.File]::WriteAllText((Join-Path $outputRoot ($client+'-'+$case.Name+'-'+$mode+'.html')),$html,$utf8)
            $legacyParameters=@{}+$parameters
            if($mode -eq 'Final'){$legacyParameters.Rows=@(Get-ThoroughFinalReportRows -Rows $parameters.Rows -ConfirmedKioskUser $parameters.KioskUserName -AfterApply $parameters.AfterApply)}
            $legacySnapshot=& $legacy @legacyParameters;$legacyHtml=Decode-Setting $legacySnapshot
            [IO.File]::WriteAllText((Join-Path $outputRoot ($client+'-'+$case.Name+'-'+$mode+'-Legacy.html')),$legacyHtml,$utf8)
            if($mode -eq 'Audit'){
                Assert-Setting ((Remove-AuditAdditionalReferenceSection $html).Replace("`r`n","`n") -ceq (Remove-AuditAdditionalReferenceSection $legacyHtml).Replace("`r`n","`n")) 'Audit presentation or observations changed outside Additional references.'
                continue
            }
            $headers=if($mode -eq 'Fix'){@('Component','Shortcut / Command','Setting','Findings','Applied')}else{@('Component','Setting','Status')}
            foreach($table in [regex]::Matches($html,'(?is)<table class="checks"[^>]*>.*?</table>')){
                $actual=@([regex]::Matches($table.Value,'<th scope="col">([^<]+)</th>')|ForEach-Object {$_.Groups[1].Value})
                Assert-Setting (($actual -join '|') -ceq ($headers -join '|')) ('Incorrect '+$mode+' columns')
            }
            $oldNames=@([regex]::Matches($legacyHtml,'<div class="device-title">([^<]+)</div>')|ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
            $newNames=@([regex]::Matches($html,'<div class="device-title">([^<]+)</div>')|ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
            Assert-Setting (($oldNames -join '|') -ceq ($newNames -join '|')) ($mode+' changed component selection')
            foreach($componentName in $oldNames){
                $component=Get-SettingRenderedComponent $html $componentName
                $legacyCells=@(Get-LegacySettingCells $legacyHtml $componentName)
                Assert-Setting ($component.Count -eq 1) ('Lost or duplicated '+$componentName)
                if($mode -eq 'Fix'){
                    $commands=@([regex]::Matches($legacyCells[1],'data-command="([^"]*)"')|ForEach-Object {[Net.WebUtility]::HtmlDecode($_.Groups[1].Value)})
                    Assert-Setting (($commands -join '|') -ceq ($component.Commands -join '|')) 'Fix changed retained copy commands.'
                    if($case.Name -ne 'NoBaseline'){
                        $legacyFields=@(Get-LegacyFieldPairs $legacyCells[2])|ForEach-Object {if($componentName -eq 'Performance Counter'){$_ -replace '^Audit=','Rebuild State='}else{$_}}
                        $currentFields=@($component.Fields|Where-Object Setting -NE 'Details'|ForEach-Object {$_.Setting+'='+$_.Findings})
                        if($componentName -eq 'Printer'){
                            # This fixture's Kitchen queue is healthy and unchanged.
                            $legacyFields=@($legacyFields | Where-Object {$_ -cne 'Printer Name=BIXOLON Kitchen'})
                            Assert-Setting (-not $component.Text.Contains('BIXOLON Kitchen')) 'Healthy unchanged printer leaked into Fix'
                        }
                        Assert-Setting (($legacyFields -join '|') -ceq ($currentFields -join '|')) ('Fix changed selected properties or pre-fix values: '+$componentName)
                    }
                    if($componentName -eq 'Printer'){
                        Assert-Setting (@($component.Fields | Where-Object {$_.Setting -eq 'Printer Name' -and ($_.Value -ne '' -or $_.Html -ne '')}).Count -eq 0) 'Printer identity has an Applied label or hidden badge'
                    }
                    if(-not $case.AfterApply){
                        $automaticFields=@($component.Fields | Where-Object {-not ($componentName -eq 'Printer' -and $_.Setting -eq 'Printer Name')})
                        Assert-Setting (-not @($automaticFields|Where-Object Value -NE 'Not applied').Count) 'An Audit-derived Fix claims applied values.'
                    }
                }else{
                    $legacyFields=@(Get-LegacyFieldPairs $legacyCells[1])
                    $currentFields=@($component.Fields|Where-Object Setting -NE 'Details'|ForEach-Object {$_.Setting+'='+$_.Value})
                    Assert-Setting (($legacyFields -join '|') -ceq ($currentFields -join '|')) ('Final changed recorded setting values: '+$componentName)
                    Assert-Setting ($component.Commands.Count -eq 0 -and $component.Html -notmatch 'class="badge') 'Final contains commands or component Pass/Fail badges.'
                }
            }
            if($case.Name -eq 'Applied' -and $mode -eq 'Fix'){
                $accounts=Get-SettingRenderedComponent $html 'KIOSK Account'
                $repaired=Get-SettingField $accounts 'User Cannot Change Password' '*Desk & <East>*'
                $failed=Get-SettingField $accounts 'User Cannot Change Password' '*SELISE-KIOSK*'
                Assert-Setting ($repaired.Findings -ceq 'Disabled' -and $repaired.Value -ceq 'Enabled' -and $failed.Value -ceq 'Disabled') 'Reordered accounts inherited a sibling post-fix value.'
                Assert-Setting ($accounts.Text -notmatch 'Healthy') 'A healthy sibling account was added to Fix.'
                $printer=Get-SettingField (Get-SettingRenderedComponent $html 'Printer') 'Keep printed documents' '*EPSON & <Front>*'
                Assert-Setting ($printer.Findings -ceq 'Disabled' -and $printer.Value -ceq 'Enabled') 'Reordered printers inherited a sibling post-fix value.'
                $counter=Get-SettingField (Get-SettingRenderedComponent $html 'Performance Counter') 'Rebuild State'
                Assert-Setting ($counter.Findings -ceq 'Not executed' -and $counter.Value -ceq 'Exit code: 0') 'Counter readback was inferred from its command exit instead of the recorded property.'
                $appView=Get-SettingRenderedComponent $html 'Payment Configuration'
                Assert-Setting (-not @($appView.Fields|Where-Object Value -NE 'Not applied').Count) 'Read-only AppSettings claims repairs.'
            }
            if($mode -eq 'Final'){
                $appView=Get-SettingRenderedComponent $html 'Payment Configuration'
                Assert-Setting ((Get-SettingField $appView 'PosId').Value -ceq '0' -and (Get-SettingField $appView 'IsEnabled').Value -ceq 'False') 'Final lost a collected zero or False value.'
                Assert-Setting ((Get-SettingRenderedComponent $html 'Opaque evidence').Text -match 'Read failed & access denied') 'Final hid opaque error evidence.'
            }
        }
        $state=[pscustomobject]@{Version=1;ClientType=$client;ComputerName='FIXTURE-PC';BundleId='OMK-241234';LatestMode='Fix';Reports=[pscustomobject]$snapshots}
        $bundle=New-ThoroughReportBundleHtml $state;$saved=Read-ThoroughReportBundleState $bundle
        Assert-Setting ($saved.Reports.Fix.HtmlBase64 -ceq $snapshots.Fix.HtmlBase64 -and $saved.Reports.Final.HtmlBase64 -ceq $snapshots.Final.HtmlBase64) 'New layouts did not round-trip through the saved report.'
        [IO.File]::WriteAllText((Join-Path $outputRoot ($client+'-'+$case.Name+'-Combined.html')),$bundle,$utf8)
        Assert-Setting ((ConvertTo-Json -InputObject @($case.Rows,$case.BeforeRows) -Depth 24 -Compress) -ceq $original) 'Rendering mutated observations or repair metadata.'
    }
    # A cached positive value must not become a verified success after a failed readback.
    $failed=$logAfter.PSObject.Copy();$failed.Status='Fail';$failed.ActionTaken='PrintService log enabled; readback failed'
    $view=New-ThoroughReportSnapshot -Rows @($failed) -BeforeRows @($logBefore) -DisplayMode Fix -AfterApply $true
    $field=Get-SettingField (Get-SettingRenderedComponent (Decode-Setting $view) 'PrintService Log') 'Log State'
    Assert-Setting ($field.Findings -ceq 'Disabled' -and $field.Value -ceq 'Not verified') 'Failed readback displayed a cached positive value.'
    $view=New-ThoroughReportSnapshot -Rows @($failed) -DisplayMode Final -AfterApply $true
    $field=Get-SettingField (Get-SettingRenderedComponent (Decode-Setting $view) 'PrintService Log') 'Log State'
    Assert-Setting ($field.Value -ceq 'Not verified') 'Final displayed a cached positive value after failed readback.'
    $missing=New-ThoroughReportSnapshot -Rows @() -BeforeRows @($logBefore) -DisplayMode Fix -AfterApply $true
    Assert-Setting ((Get-SettingRenderedComponent (Decode-Setting $missing) 'PrintService Log').Fields[0].Value -ceq 'Not verified') 'A missing post-fix component acquired an applied value.'
    $ambiguous=$accountAfter.PSObject.Copy();$ambiguous.AccountResults=@($accountAfter.AccountResults)+@($accountAfter.AccountResults[2])
    $view=New-ThoroughReportSnapshot -Rows @($ambiguous) -BeforeRows @($accountBefore) -DisplayMode Fix -AfterApply $true
    $field=Get-SettingField (Get-SettingRenderedComponent (Decode-Setting $view) 'KIOSK Account') 'User Cannot Change Password' '*Desk & <East>*'
    Assert-Setting ($field.Value -ceq 'Not verified') 'Duplicate account result metadata fabricated a successful post-fix value.'
    $view=New-ThoroughReportSnapshot -Rows @($ambiguous) -DisplayMode Final -AfterApply $true -KioskUserName 'Desk & <East>'
    $field=Get-SettingField (Get-SettingRenderedComponent (Decode-Setting $view) 'KIOSK Account') 'User Cannot Change Password'
    Assert-Setting ($field.Value -ceq 'Not verified') 'Final treated ambiguous account results as verified current values.'
    # A sibling printer's failed readback must not invalidate a verified repair.
    $partial=@($afterPrinters|ForEach-Object {$_.PSObject.Copy()})
    $partial[0].Status='Fail';$partial[0].ActionTaken='Enabled Keep printed documents; readback failed'
    $view=New-ThoroughReportSnapshot -Rows $partial -BeforeRows $beforePrinters -DisplayMode Fix -AfterApply $true
    $printer=Get-SettingField (Get-SettingRenderedComponent (Decode-Setting $view) 'Printer') 'Keep printed documents' '*EPSON & <Front>*'
    Assert-Setting ($printer.Value -ceq 'Enabled') 'A sibling printer failure invalidated the verified printer result.'
    $view=New-ThoroughReportSnapshot -Rows $partial -DisplayMode Final -AfterApply $true
    $printers=Get-SettingRenderedComponent (Decode-Setting $view) 'Printer'
    Assert-Setting (-not $printers.Text.Contains('BIXOLON') -and (Get-SettingField $printers 'Keep printed documents').Value -ceq 'Enabled') 'Final retained unverified printer state or lost its verified sibling.'
    # Repeated labels may be paired by occurrence only when counts agree.
    $duplicate=New-SettingFixture 4 'Duplicate property fixture' ((ConvertTo-ReportDefinitionHtml ([ordered]@{'Value'='One'}))+(ConvertTo-ReportDefinitionHtml ([ordered]@{'Value'='Two'})))
    $single=New-SettingFixture 4 'Duplicate property fixture' ([ordered]@{'Value'='Three'}) Remediated 'Fixture repair completed; readback verified'
    $view=New-ThoroughReportSnapshot -Rows @($single) -BeforeRows @($duplicate) -DisplayMode Fix -AfterApply $true
    $component=Get-SettingRenderedComponent (Decode-Setting $view) 'Duplicate property fixture'
    Assert-Setting ($component.Fields.Count -eq 2 -and -not @($component.Fields|Where-Object Value -NE 'Not verified').Count) 'An ambiguous repeated label acquired a guessed Applied value.'
    Assert-Setting (-not (Test-CanApply)) 'Rendering enabled the repair gate.'
    Write-Output ('PASS: '+$client+' Fix/Final setting values; historical component/property/command parity; reordered records; failed/missing readback; ambiguous metadata; zero/False; unchanged Audit and source observations.')
}
